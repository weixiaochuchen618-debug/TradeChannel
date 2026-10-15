#requires -Version 5.1
[CmdletBinding()]
param([string]$Url='https://1.1.1.1/cdn-cgi/trace',[ValidateSet('Trade','Daily')][string]$Lane='Trade',[ValidateRange(3,20)][int]$ConnectTimeoutSeconds=12,[ValidateRange(5,25)][int]$TimeoutSeconds=15)
$ErrorActionPreference='Stop'
$uri=[Uri]$Url
if($uri.Scheme -ne 'https'){throw 'Only HTTPS diagnostics are accepted.'}
$d=Get-Content -LiteralPath (Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'TradeChannel\deployment.json') -Raw|ConvertFrom-Json
$m=Get-Content -LiteralPath $d.ManifestPath -Raw|ConvertFrom-Json
$cfg=Get-Content -LiteralPath $m.CandidatePath -Raw|ConvertFrom-Json
$in=@($cfg.inbounds|Where-Object {$_.tag -eq 'egress-probe'})
if($in.Count -ne 1 -or $in[0].listen -ne '127.0.0.1' -or -not $in[0].users[0].password){throw 'Authenticated loopback probe was not configured.'}
# The trade probe user follows trade-exit; the daily probe user follows daily-exit.
$wantedUser=if($Lane -eq 'Daily'){'tradechannel-daily'}else{'tradechannel-probe'}
$user=@($in[0].users|Where-Object {$_.username -eq $wantedUser})
if(-not $user.Count){if($Lane -eq 'Daily'){throw 'This line configuration has no daily probe; upgrade the line first.'};$user=@($in[0].users[0])}
$escapedUrl=$uri.AbsoluteUri.Replace('\','\\').Replace('"','\"')
$settings=@(
    ('proxy = "http://127.0.0.1:'+$in[0].listen_port+'"'),
    ('proxy-user = "'+$user[0].username+':'+$user[0].password+'"'),
    'noproxy = ".invalid"',
    'silent','show-error',('connect-timeout = '+$ConnectTimeoutSeconds),('max-time = '+$TimeoutSeconds),
    ('url = "'+$escapedUrl+'"'),
    'write-out = "\nTC_HTTP:%{http_code}"'
) -join "`n"
$si=New-Object Diagnostics.ProcessStartInfo
$si.FileName=(Get-Command curl.exe).Source;$si.Arguments='--config -'
$si.UseShellExecute=$false;$si.CreateNoWindow=$true;$si.RedirectStandardInput=$true;$si.RedirectStandardOutput=$true;$si.RedirectStandardError=$true
$p=New-Object Diagnostics.Process;$p.StartInfo=$si
$savedEncoding=[Console]::InputEncoding
try{
    [Console]::InputEncoding=[Text.Encoding]::ASCII
    $null=$p.Start();$bytes=[Text.Encoding]::UTF8.GetBytes($settings)
    $p.StandardInput.BaseStream.Write($bytes,0,$bytes.Length);$p.StandardInput.BaseStream.Close();[Array]::Clear($bytes,0,$bytes.Length)
    $stdout=$p.StandardOutput.ReadToEndAsync();$stderr=$p.StandardError.ReadToEndAsync()
    if(-not $p.WaitForExit(($TimeoutSeconds+3)*1000)){$p.Kill();$null=$p.WaitForExit(3000);throw 'Diagnostic process exceeded its time budget.'}
    $body=$stdout.GetAwaiter().GetResult();$null=$stderr.GetAwaiter().GetResult()
    $ip=$null;if($uri.AbsolutePath -eq '/cdn-cgi/trace' -and $body -match '(?m)^ip=([^\r\n]+)'){$ip=$matches[1].Trim()}
    $http=$null;if($body -match '(?m)^TC_HTTP:(\d{3})'){$http=[int]$matches[1]}
    [pscustomobject]@{Url=$Url;Lane=$Lane;CurlExit=$p.ExitCode;HTTPStatus=$http;ObservedIP=$ip;Via=('Authenticated local diagnostic inlet -> '+$(if($Lane -eq 'Daily'){'selected daily exit'}else{'manually selected trade exit'}))}
}finally{if($p -and -not $p.HasExited){$p.Kill();$null=$p.WaitForExit(3000)};$p.Dispose();[Console]::InputEncoding=$savedEncoding;$settings=$null;$cfg=$null;$in=$null;$user=$null;$body=$null}
