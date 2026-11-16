#requires -Version 5.1
# 0.22.0 A1: the invitation lifetime chain stays aligned and the join side
# accepts up to 24 hours. No network, no host process, no UI thread.
param([Parameter(Mandatory=$true)][string]$PackageDirectory,[string]$ReportPath)
$ErrorActionPreference='Stop';$script:checks=0
function Check {param($ok,$name)if(-not $ok){throw $name};$script:checks++}
function Get-Code {param([long]$Expires,[string]$InviteId)
    if(-not $InviteId){$InviteId=[guid]::NewGuid().ToString('D')}
    $body=[ordered]@{v=1;h='127.0.0.1';p=18443;i=$InviteId;k=('a'*43);t=('b'*64);m=('SHA256:'+('c'*43));e=$Expires}
    $json=($body|ConvertTo-Json -Compress)
    $encoded=[Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($json)).TrimEnd('=').Replace('+','-').Replace('/','_')
    return ('TCI1.'+$encoded)
}
try{
    # The SSH/TLS transport is irrelevant to parsing; a stub type keeps
    # Initialize-TCPairOnline from loading the packaged dependency set.
    Add-Type -TypeDefinition 'namespace TradeChannel.Deployment { public static class PairingOnlineTransport { } }'
    $module=Import-Module (Join-Path $PackageDirectory 'PairingOnline.psm1') -Force -PassThru -DisableNameChecking

    # --- 1. Join side accepts up to 24 hours and nothing longer ---------------
    $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $accepted=& $module {param($c)ConvertFrom-TCPairOnlineCode -InvitationCode $c -AllowLoopback} (Get-Code ($now+86400))
    Check ([long]$accepted.ExpiresUnix -eq ($now+86400)) 'a code expiring in 24 hours is accepted'
    Check ($accepted.Url -like 'https://127.0.0.1:18443/v1/invitations/*') 'the accepted code keeps its invitation URL'
    $grace=& $module {param($c)ConvertFrom-TCPairOnlineCode -InvitationCode $c -AllowLoopback} (Get-Code ($now+86400+300))
    Check ($null -ne $grace) 'the 300 second clock skew allowance is accepted'
    $short=& $module {param($c)ConvertFrom-TCPairOnlineCode -InvitationCode $c -AllowLoopback} (Get-Code ($now+60))
    Check ($null -ne $short) 'a one minute invitation is still accepted'
    # The bound is measured against the clock read inside the parser, so each
    # boundary code is stamped from a fresh reading right before the call.
    $rejected=$null
    $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    try{$null=& $module {param($c)ConvertFrom-TCPairOnlineCode -InvitationCode $c -AllowLoopback} (Get-Code ($now+86400+301))}catch{$rejected=$_.Exception.Message}
    Check ($rejected -like '*InvalidOnlineCode*') 'anything beyond 24 hours plus the skew allowance is refused'
    $expired=$null
    $now=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    try{$null=& $module {param($c)ConvertFrom-TCPairOnlineCode -InvitationCode $c -AllowLoopback} (Get-Code ($now-30))}catch{$expired=$_.Exception.Message}
    Check ($expired -like '*OnlineInviteExpired*') 'an expired code still reports OnlineInviteExpired'

    # --- 2. The three bounds are the same number in all three places ---------
    $python=[IO.File]::ReadAllText((Join-Path $PackageDirectory 'linux\pairing_online.py'))
    Check ($python -match '(?m)^MAX_LIFETIME = 86400$') 'the server owns a 24 hour maximum lifetime'
    Check ($python -match '(?m)^RETRY_SECONDS = 120$') 'the server keeps the 120 second retry window'
    $online=[IO.File]::ReadAllText((Join-Path $PackageDirectory 'PairingOnline.psm1'))
    Check ($online -match '\$now\+86400\+300') 'the join side allows 24 hours plus 300 seconds'
    $host43=[IO.File]::ReadAllText((Join-Path $PackageDirectory 'deployment\TradeChannelDeployHost.cs'))
    Check ($host43 -match '\(int\)value<60\|\|\(int\)value>86400') 'the deploy host accepts 60..86400 seconds'

    # --- 3. The page sends the chosen seconds, not a constant ----------------
    $pagePath=Join-Path $PackageDirectory 'ui\OnlinePairingPages.ps1'
    $page=[IO.File]::ReadAllText($pagePath)
    Check ($page -match 'ExpiresInSeconds=\$lifetime\.Seconds') 'the invitation uses the lifetime chosen on the page'
    Check (-not ($page -match 'ExpiresInSeconds=600')) 'the page no longer hard codes ten minutes'
    Check (-not ($page -match '生成后 10 分钟内有效')) 'the explanation no longer promises a fixed ten minutes'
    Check (-not ($page -match '生成邀请码（10 分钟）')) 'the button label no longer promises a fixed ten minutes'
    Check ($page -match [regex]::Escape('超过 30 分钟的邀请码，新电脑需要 0.22.0 或更高版本；旧版本会提示有效期超过上限。')) 'the compatibility warning is present verbatim'

    # --- 4. The lifetime helpers work without the window --------------------
    . (Join-Path $PackageDirectory 'ui\OnlinePairingPages.ps1')
    function ServerUIGet {param($Value,[string]$Name,$Default=$null)
        if($Value -is [Collections.IDictionary]){if($Value.Contains($Name)){return $Value[$Name]}}
        elseif($null -ne $Value -and $Value.PSObject.Properties[$Name]){return $Value.$Name}
        return $Default
    }
    $script:DeployUI=@{Management=@{Input=@{}}}
    $presets=@($script:OnlineInviteLifetimePresets|ForEach-Object {[int]$_.Seconds})
    Check (($presets -join ',') -eq '600,1800,7200,86400') 'the four presets are 10 minutes, 30 minutes, 2 hours and 24 hours'
    Check ($script:OnlineInviteLifetimeDefaultSeconds -eq 1800) 'the default lifetime is 30 minutes'
    Check ($script:OnlineInviteLifetimeCompatLimitSeconds -eq 1800) 'the compatibility warning starts above 30 minutes'
    Check ((Format-OnlineInviteLifetime 600) -eq '10 分钟') 'ten minutes formats as minutes'
    Check ((Format-OnlineInviteLifetime 1800) -eq '30 分钟') 'thirty minutes formats as minutes'
    Check ((Format-OnlineInviteLifetime 7200) -eq '2 小时') 'two hours formats as whole hours'
    Check ((Format-OnlineInviteLifetime 86400) -eq '24 小时') 'twenty four hours formats as whole hours'
    Check ((Format-OnlineInviteLifetime 5400) -eq '1 小时 30 分钟') 'a mixed duration keeps both parts'
    Check ((Format-OnlineInviteLifetime 86399) -eq '24 小时') 'a deadline one second short of a day still reads as a day'
    Check ((ConvertTo-OnlineInviteLifetimeSeconds '10' 'Minutes').Seconds -eq 600) 'ten minutes is the smallest custom value'
    Check ((ConvertTo-OnlineInviteLifetimeSeconds '1440' 'Minutes').Seconds -eq 86400) '1440 minutes is the largest custom value'
    Check ([string](ConvertTo-OnlineInviteLifetimeSeconds '9' 'Minutes').Error) 'nine minutes is refused'
    Check ([string](ConvertTo-OnlineInviteLifetimeSeconds '1441' 'Minutes').Error) '1441 minutes is refused'
    Check ((ConvertTo-OnlineInviteLifetimeSeconds '1' 'Hours').Seconds -eq 3600) 'one hour is the smallest custom hour value'
    Check ((ConvertTo-OnlineInviteLifetimeSeconds '24' 'Hours').Seconds -eq 86400) '24 hours is the largest custom hour value'
    Check ([string](ConvertTo-OnlineInviteLifetimeSeconds '25' 'Hours').Error) '25 hours is refused'
    Check ([string](ConvertTo-OnlineInviteLifetimeSeconds '12.5' 'Minutes').Error) 'a fractional entry is refused'
    Check ([string](ConvertTo-OnlineInviteLifetimeSeconds '' 'Minutes').Error) 'an empty entry is refused'
    Check ((ConvertTo-OnlineInviteLifetimeSeconds ' 45 ' 'Minutes').Seconds -eq 2700) 'surrounding spaces are tolerated'
    $default=GetOnlineInviteLifetimeUI
    Check ($default.Seconds -eq 1800 -and $default.Valid -and -not $default.Compat -and $default.Label -eq '30 分钟') 'an untouched page offers 30 minutes without a warning'
    $script:DeployUI.Management.Input.InviteLifetimeSeconds=7200
    $twoHours=GetOnlineInviteLifetimeUI
    Check ($twoHours.Seconds -eq 7200 -and $twoHours.Compat) 'a preset above 30 minutes raises the compatibility warning'
    $script:DeployUI.Management.Input.InviteLifetimeCustom=$true
    $script:DeployUI.Management.Input.InviteLifetimeAmount='90'
    $script:DeployUI.Management.Input.InviteLifetimeUnit='Minutes'
    $custom=GetOnlineInviteLifetimeUI
    Check ($custom.Seconds -eq 5400 -and $custom.Valid -and $custom.Compat -and $custom.Label -eq '1 小时 30 分钟') 'a custom 90 minutes becomes 5400 seconds'
    $script:DeployUI.Management.Input.InviteLifetimeAmount='5'
    $invalid=GetOnlineInviteLifetimeUI
    Check (-not $invalid.Valid -and [string]$invalid.Error) 'an unusable custom entry blocks generation'
    $stamp=[DateTimeOffset]::UtcNow.AddSeconds(1800).ToString('o')
    Check ((FormatOnlineInviteRemaining $stamp) -eq '30 分钟') 'the granted lifetime is reported back in minutes'
    Check ((FormatOnlineInviteRemaining ([DateTimeOffset]::UtcNow.AddSeconds(86400).ToString('o'))) -eq '24 小时') 'a full day is reported back in hours'
    Check ((FormatOnlineInviteRemaining ([DateTimeOffset]::UtcNow.AddSeconds(-5).ToString('o'))) -eq '') 'an expired invitation has no remaining time'
    Check ((FormatOnlineInviteRemaining 'not-a-time') -eq '') 'an unreadable deadline yields no text'
    $result=[pscustomobject]@{Passed=$true;Checks=$script:checks;NetworkAccess=$false;WindowOpened=$false}
}catch{
    $result=[pscustomobject]@{Passed=$false;Checks=$script:checks;Error=$_.Exception.Message;NetworkAccess=$false;WindowOpened=$false}
}
if($ReportPath){$result|ConvertTo-Json|Set-Content -LiteralPath $ReportPath -Encoding UTF8}
$result|ConvertTo-Json
if(-not $result.Passed){exit 1}
