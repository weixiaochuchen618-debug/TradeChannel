#requires -Version 5.1
[CmdletBinding()]
param([string]$Url='https://1.1.1.1/cdn-cgi/trace')
$ErrorActionPreference='Stop'
$uri=[Uri]$Url
if($uri.Scheme -ne 'https'){throw 'Only HTTPS diagnostics are accepted.'}
$d=Get-Content -LiteralPath 'C:\ProgramData\TradeChannel\deployment.json' -Raw|ConvertFrom-Json
$m=Get-Content -LiteralPath $d.ManifestPath -Raw|ConvertFrom-Json
$cfg=Get-Content -LiteralPath $m.CandidatePath -Raw|ConvertFrom-Json
$in=@($cfg.inbounds|Where-Object {$_.tag -eq 'egress-probe'})
if($in.Count -ne 1 -or $in[0].listen -ne '127.0.0.1' -or -not $in[0].users[0].password){throw 'Authenticated loopback probe was not configured.'}
$escapedUrl=$uri.AbsoluteUri.Replace('\','\\').Replace('"','\"')
$settings=@(
    ('proxy = "http://127.0.0.1:'+$in[0].listen_port+'"'),
    ('proxy-user = "'+$in[0].users[0].username+':'+$in[0].users[0].password+'"'),
    'noproxy = ".invalid"',
    'silent','show-error','connect-timeout = 5','max-time = 12',
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
    $body=$p.StandardOutput.ReadToEnd();$err=$p.StandardError.ReadToEnd();$p.WaitForExit()
    $ip=$null;if($uri.AbsolutePath -eq '/cdn-cgi/trace' -and $body -match '(?m)^ip=([^\r\n]+)'){$ip=$matches[1].Trim()}
    $http=$null;if($body -match '(?m)^TC_HTTP:(\d{3})'){$http=[int]$matches[1]}
    [pscustomobject]@{Url=$Url;CurlExit=$p.ExitCode;HTTPStatus=$http;ObservedIP=$ip;Via='Authenticated local diagnostic inlet -> manually selected trade exit'}
}finally{$p.Dispose();[Console]::InputEncoding=$savedEncoding;$settings=$null;$cfg=$null;$in=$null}
